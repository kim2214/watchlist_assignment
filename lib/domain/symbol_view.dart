/// 프레젠테이션 계층이 보는 **불변** 뷰 모델들.
///
/// raw [QuoteTick] 은 여기까지 내려오지 않는다. Store가 정합성(timestampMs 가드),
/// 거래정지, 파생값(등락률)을 모두 계산해 아래 불변 객체로만 노출한다.
library;

/// 한 종목의 "휘발성(실시간으로 바뀌는)" 상태만 담는다.
/// 종목명/코드/시장 같은 정적 메타는 여기 넣지 않는다(행 위젯이 symbols에서 직접 읽음)
/// — notifier가 나르는 값을 최소화해 rebuild 시 할당 비용을 줄인다.
class SymbolView {
  const SymbolView({
    required this.price,
    required this.changePct,
    required this.dayVolume,
    required this.halted,
  });

  final double price;
  final double changePct;
  final int dayVolume;
  final bool halted;
}

/// 상단 요약 영역 값.
class MarketSummary {
  const MarketSummary({required this.count, required this.totalMarketCap});

  /// 표시 중(현재는 전체) 종목 수.
  final int count;

  /// 시가총액 합계 (현재가 × 상장주식수의 총합).
  final double totalMarketCap;
}

/// 종목 상세 화면용 뷰. tick 흐름에서 누적한 파생값 포함.
class DetailView {
  const DetailView({
    required this.code,
    required this.name,
    required this.price,
    required this.previousClose,
    required this.changeAbs,
    required this.changePct,
    required this.open,
    required this.high,
    required this.low,
    required this.dayVolume,
    required this.halted,
    required this.spark,
  });

  final String code;
  final String name;
  final double price;
  final double previousClose;

  /// 전일 대비 등락폭(원) / 등락률(%).
  final double changeAbs;
  final double changePct;

  /// 세션 동안 tick 흐름에서 누적한 시가(구독 시점가)·고가·저가.
  final double open;
  final double high;
  final double low;

  final int dayVolume;
  final bool halted;

  /// 최근 N개 체결가(스파크라인용). 오래된 것부터.
  final List<double> spark;
}

/// 등락률 상위 목록의 한 항목.
class TopMover {
  const TopMover({
    required this.code,
    required this.name,
    required this.changePct,
    required this.price,
    required this.halted,
  });

  final String code;
  final String name;
  final double changePct;
  final double price;
  final bool halted;
}
