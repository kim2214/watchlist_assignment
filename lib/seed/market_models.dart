/// ============================================================================
/// DOMAIN SEED — 수정하지 마세요 (Do NOT modify)
/// ============================================================================
///
/// 이 파일은 "데이터 소스가 주는 원시(raw) 형태"를 정의합니다.
/// 과제의 시작점일 뿐, 앱 전역에서 이 타입을 그대로 쓰라는 뜻은 아닙니다.
///
/// - 프레젠테이션 계층까지 이 raw 타입을 그대로 흘려보낼지,
/// 별도의 도메인/뷰 모델로 변환할지는 여러분의 설계 판단입니다.
/// - 변환한다면 그 경계(boundary)를 어디에 둘지, 왜 그렇게 했는지를
/// DESIGN.md에 적어 주세요.
/// ============================================================================

library;

enum MarketType { kospi, kosdaq }

/// 종목의 실시간 거래 상태.
///
/// feed는 정상 거래 중에는 [active] tick을, 거래정지 구간에는 [halted] tick을
/// 내보냅니다. 정지 상태를 어떻게 표시/누적할지는 여러분의 설계 판단입니다.
enum QuoteStatus {
  /// 정상 거래 중.
  active,

  /// 거래정지(halt). 이 구간의 [QuoteTick.price] 는 직전 체결가로 고정되며,
  /// 등락률·시총 등 파생값에 정지 구간을 어떻게 반영할지는 여러분이 정합니다.
  halted,
}

/// 종목의 정적 메타데이터. 앱 수명 동안 바뀌지 않습니다.
class SymbolInfo {
  const SymbolInfo({
    required this.code,
    required this.name,
    required this.market,
    required this.listedShares,
  });

  /// 6자리 종목코드. 예: "005930"
  final String code;

  /// 종목명. 예: "삼성전자"
  final String name;

  final MarketType market;

  /// 상장 주식 수 (시가총액 계산에 사용).
  final int listedShares;
}

/// 스트림으로 밀려오는 한 건의 시세 갱신.
///
/// feed는 이 값을 **배치(`List<QuoteTick>`)** 로, 초당 수천 건 규모로 내보냅니다.
/// 한 배치 안에 같은 종목이 여러 번 등장하지 않습니다.
///
/// 주의: 실제 피드와 마찬가지로 **도착 순서가 시간 순서와 일치하지 않을 수
/// 있습니다.** 일부 tick은 지연되어, 더 최신 tick보다 나중에(=더 작은
/// [timestampMs] 를 달고) 도착합니다. 도착 순서만 믿고 마지막 값을 그대로
/// 반영하면 가격이 과거로 되돌아갈 수 있습니다. 정합성은 [timestampMs] 로
/// 여러분이 보장해야 합니다.
class QuoteTick {
  const QuoteTick({
    required this.code,
    required this.price,
    required this.dayVolume,
    required this.timestampMs,
    this.status = QuoteStatus.active,
  });

  final String code;

  /// 현재가 (원). [status] 가 [QuoteStatus.halted] 이면 직전 체결가로 고정됩니다.
  final double price;

  /// 당일 누적 거래량.
  final int dayVolume;

  /// 이 tick이 관측된 시각 (feed 내부 시계 기준, epoch milliseconds).
  /// **도착 순서와 무관하게** 이 값이 이벤트의 실제 시간 순서입니다.
  final int timestampMs;

  /// 이 tick 시점의 거래 상태.
  final QuoteStatus status;
}

/// feed 구독 직후 받는 전체 스냅샷의 한 종목 항목.
class QuoteSnapshotEntry {
  const QuoteSnapshotEntry({
    required this.info,
    required this.previousClose,
    required this.price,
    required this.dayVolume,
  });

  final SymbolInfo info;

  /// 전일 종가. 등락률/등락폭 계산의 기준값이며, 세션 동안 고정입니다.
  final double previousClose;

  final double price;
  final int dayVolume;
}
