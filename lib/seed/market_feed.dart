/// ============================================================================
/// DOMAIN SEED — 수정하지 마세요 (Do NOT modify)
/// ============================================================================
///
/// [MarketFeed] 는 여러분이 상대해야 하는 "실시간 시세 데이터 소스"입니다.
/// 실제 서비스의 폴링/WebSocket 피드를 로컬에서 재현한 것으로, 다음 특성을 가집니다.
///
/// - 종목 2,000개 (KOSPI/KOSDAQ 혼합)
/// - [start] 이후 고빈도로 시세 배치를 [ticks] 스트림에 흘려보냄
/// 기본값: 초당 60배치 × 배치당 최대 250건 ≈ 초당 최대 15,000 갱신
/// - broadcast stream 이므로 여러 구독자가 붙을 수 있음
/// - **지연·역순 tick**: 일부 tick은 지연되어 더 최신 tick보다 나중에
/// (=더 작은 timestampMs를 달고) 도착합니다. 도착 순서 = 시간 순서가 아닙니다.
/// - **거래정지(halt)**: 종목이 수시로 정지/해제됩니다. 정지 구간의 tick은
/// [QuoteStatus.halted] 이고 가격이 고정됩니다.
/// - **일시적 스트림 에러**: 실제 소켓처럼 [ticks] 스트림이 간헐적으로 에러를
/// 낼 수 있습니다(기본 확률 0 — 평가자가 [transientErrorProbability] 로 켭니다).
/// 구독자는 에러에도 살아남아 갱신을 이어갈 수 있어야 합니다.
///
/// 결정론성: 모든 무작위성은 생성자 [seed] 하나에서 나옵니다. 같은 seed + 같은
/// 배치 수열이면 tick 시퀀스가 **바이트 단위로 재현**됩니다. 벤치마크는 [start]
/// 대신 [pump] 로 배치를 결정론적으로 밀어 넣어 before/after를 공정하게 비교하세요.
///
/// 이 클래스의 동작/시그니처는 고정입니다. 여기에 캐싱·throttle·변환·정렬을 넣지
/// 마세요. 그런 처리는 여러분이 이 위에 쌓을 계층의 책임입니다.
///
/// 이 feed를 앱에서 어떻게 소비할지 — 어떤 추상화로 감쌀지, 어디서 throttle/batch
/// 할지, 어떤 단위로 rebuild를 유발할지 — 가 이번 과제의 핵심입니다.
/// ============================================================================
library;

import 'dart:async';
import 'dart:math';

import 'market_models.dart';

class MarketFeed {
  MarketFeed({
    this.symbolCount = 2000,
    this.batchesPerSecond = 60,
    this.updatesPerBatch = 250,
    this.lateTickProbability = 0.008,
    this.haltProbability = 0.002,
    this.transientErrorProbability = 0.0,
    int seed = 20260703,
  }) : _random = Random(seed) {
    _buildUniverse();
  }

  /// 생성할 종목 수.
  final int symbolCount;

  /// 초당 스트림 배치 수 (기본 60Hz).
  final int batchesPerSecond;

  /// 한 배치에서 갱신되는 종목 수의 상한.
  final int updatesPerBatch;

  /// tick 하나가 지연되어 나중 배치에서 (더 작은 timestampMs로) 방출될 확률.
  /// 도착 순서 ≠ 시간 순서 상황을 재현합니다.
  final double lateTickProbability;

  /// 매 배치에서 새 거래정지가 발생할 확률. 정지는 1~6초 뒤 자동 해제됩니다.
  final double haltProbability;

  /// 매 배치 후 [ticks] 스트림에 일시적 에러를 실을 확률.
  /// 기본 0(꺼짐). 평가자는 이 값을 올려 에러 복구 설계를 검증할 수 있습니다.
  final double transientErrorProbability;

  final Random _random;

  final List<SymbolInfo> _symbols = [];
  final Map<String, double> _previousClose = {};
  final Map<String, double> _price = {};
  final Map<String, int> _dayVolume = {};

  /// 현재 거래정지 중인 종목 → 해제 예정 배치 index.
  final Map<String, int> _haltedUntilBatch = {};

  /// 방출이 지연된 tick들. (원본 timestamp를 유지한 채) 예정 배치에서 풀린다.
  final List<_DelayedTick> _delayed = [];

  int _clockMs = 0;
  int _batchIndex = 0;
  Timer? _timer;

  final StreamController<List<QuoteTick>> _controller =
      StreamController<List<QuoteTick>>.broadcast();

  /// 2,000개 종목의 정적 메타데이터. 순서는 고정입니다.
  List<SymbolInfo> get symbols => List.unmodifiable(_symbols);

  /// 구독 시작 시점의 전체 시세 스냅샷.
  List<QuoteSnapshotEntry> initialSnapshot() {
    return _symbols
        .map(
          (info) => QuoteSnapshotEntry(
            info: info,
            previousClose: _previousClose[info.code]!,
            price: _price[info.code]!,
            dayVolume: _dayVolume[info.code]!,
          ),
        )
        .toList(growable: false);
  }

  /// 고빈도 시세 배치 스트림. [start] 를 호출해야 흐르기 시작합니다.
  Stream<List<QuoteTick>> get ticks => _controller.stream;

  void start() {
    if (_timer != null) return;
    final period = Duration(microseconds: 1000000 ~/ batchesPerSecond);
    _timer = Timer.periodic(period, (_) => _emitBatch());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 결정론적 벤치마크용. 타이머 없이 [count]개의 배치를 즉시 방출합니다.
  ///
  /// [start] 와 달리 벽시계에 의존하지 않으므로, 같은 seed로는 항상 같은 tick
  /// 수열이 재현됩니다. before/after 성능 비교는 이 API로 동일 시나리오를 돌려
  /// 측정하세요. (호출 전에 [ticks] 에 리스너가 붙어 있어야 방출됩니다.)
  void pump([int count = 1]) {
    for (var i = 0; i < count; i++) {
      _emitBatch();
    }
  }

  void dispose() {
    stop();
    _controller.close();
  }

  void _emitBatch() {
    if (_controller.isClosed || !_controller.hasListener) return;
    _batchIndex++;
    _clockMs += 1000 ~/ batchesPerSecond;

    _updateHalts();

    final batch = <QuoteTick>[];
    final touched = <String>{};

    // 지연되었던 tick을 (원래의 오래된 timestamp 그대로) 먼저 풀어 넣는다.
    _releaseDelayed(batch, touched);

    // 한 배치에 한 종목은 최대 1건이므로, 요청 건수는 종목 수를 넘을 수 없다.
    // (지연 tick도 touched를 소비하므로) touched가 전 종목을 덮으면 종료한다.
    final count = 1 + _random.nextInt(updatesPerBatch);

    while (batch.length < count && touched.length < _symbols.length) {
      final info = _symbols[_random.nextInt(_symbols.length)];
      if (!touched.add(info.code)) continue;

      // 거래정지 종목: 가격 고정, 상태만 halted로 알린다.
      if (_haltedUntilBatch.containsKey(info.code)) {
        batch.add(
          QuoteTick(
            code: info.code,
            price: _price[info.code]!,
            dayVolume: _dayVolume[info.code]!,
            timestampMs: _clockMs,
            status: QuoteStatus.halted,
          ),
        );
        continue;
      }

      final prev = _price[info.code]!;
      // 호가단위(tick) 기준 -2~+2 단위의 랜덤워크.
      // 곱셈 drift가 호가단위보다 작으면 _roundToTick 반올림에 먹혀 현재가가
      // 고정되므로, 이동을 호가단위로 양자화해 항상 실제로 갱신되게 한다.
      final tickSize = _tickSizeFor(prev);
      final steps = _random.nextInt(5) - 2; // -2, -1, 0, +1, +2
      final prevClose = _previousClose[info.code]!;
      // 일일 등락 제한(±30%)을 전일 종가 기준으로 건다.
      final next = (prev + steps * tickSize).clamp(
        prevClose * 0.7,
        prevClose * 1.3,
      );
      final rounded = _roundToTick(next);
      _price[info.code] = rounded;
      _dayVolume[info.code] = _dayVolume[info.code]! + _random.nextInt(500);

      final tick = QuoteTick(
        code: info.code,
        price: rounded,
        dayVolume: _dayVolume[info.code]!,
        timestampMs: _clockMs,
      );

      // 낮은 확률로 이 tick을 지연시킨다. 그 사이 같은 종목의 후속 tick이 먼저
      // 나가므로, 이 tick은 나중에 "과거 시각"을 달고 도착한다(=역순 도착).
      if (_random.nextDouble() < lateTickProbability) {
        _delayed.add(_DelayedTick(tick, _batchIndex + 1 + _random.nextInt(3)));
      } else {
        batch.add(tick);
      }
    }

    _controller.add(batch);

    if (transientErrorProbability > 0 &&
        _random.nextDouble() < transientErrorProbability) {
      _controller.addError(
        const MarketFeedException('일시적 피드 오류 (재구독 없이 복구 가능)'),
      );
    }
  }

  /// 정지 해제 시각이 지난 종목을 풀고, 낮은 확률로 새 정지를 건다.
  void _updateHalts() {
    _haltedUntilBatch.removeWhere((_, until) => _batchIndex >= until);
    if (_random.nextDouble() < haltProbability) {
      final info = _symbols[_random.nextInt(_symbols.length)];
      // 1~6초(60~360배치) 동안 정지.
      _haltedUntilBatch[info.code] = _batchIndex + 60 + _random.nextInt(300);
    }
  }

  /// 예정 배치에 도달한 지연 tick을 batch에 방출한다.
  /// 같은 배치에 같은 종목이 중복되지 않도록, 이미 나간 종목은 다음 배치로 미룬다.
  void _releaseDelayed(List<QuoteTick> batch, Set<String> touched) {
    if (_delayed.isEmpty) return;
    _delayed.removeWhere((d) {
      if (_batchIndex < d.releaseAtBatch) return false;
      if (!touched.add(d.tick.code)) return false;
      batch.add(d.tick);
      return true;
    });
  }

  void _buildUniverse() {
    for (var i = 0; i < symbolCount; i++) {
      final code = (i + 1).toString().padLeft(6, '0');
      final market = i.isEven ? MarketType.kospi : MarketType.kosdaq;
      final base = 1000 + _random.nextInt(490000).toDouble();
      final basePrice = _roundToTick(base);

      _symbols.add(
        SymbolInfo(
          code: code,
          name: _nameFor(i),
          market: market,
          listedShares: 1000000 + _random.nextInt(500000000),
        ),
      );
      _previousClose[code] = basePrice;
      _price[code] = basePrice;
      _dayVolume[code] = _random.nextInt(2000000);
    }
  }

  String _nameFor(int i) {
    const prefixes = [
      '가온',
      '나래',
      '다온',
      '라온',
      '마루',
      '바로',
      '사라',
      '아라',
      '자람',
      '차미',
      '카나',
      '타온',
      '파랑',
      '하늘',
      '누리',
      '온새',
    ];
    const suffixes = [
      '전자',
      '화학',
      '바이오',
      '중공업',
      '제약',
      '통신',
      '엔터',
      '소재',
      '에너지',
      '금융',
      '물산',
      '테크',
      '반도체',
      '건설',
      '식품',
      '항공',
    ];
    final p = prefixes[i % prefixes.length];
    final s = suffixes[(i ~/ prefixes.length) % suffixes.length];
    return '$p$s';
  }

  /// 국내 주식 호가단위를 대략적으로 흉내낸 호가단위.
  int _tickSizeFor(double price) {
    if (price < 2000) return 1;
    if (price < 5000) return 5;
    if (price < 20000) return 10;
    if (price < 50000) return 50;
    if (price < 200000) return 100;
    if (price < 500000) return 500;
    return 1000;
  }

  /// 국내 주식 호가단위를 대략적으로 흉내낸 반올림.
  double _roundToTick(double price) {
    final tick = _tickSizeFor(price);
    return (price / tick).round() * tick.toDouble();
  }
}

/// 방출이 지연된 tick과 그 해제 예정 배치 index.
class _DelayedTick {
  const _DelayedTick(this.tick, this.releaseAtBatch);

  final QuoteTick tick;
  final int releaseAtBatch;
}

/// [MarketFeed.ticks] 스트림이 낼 수 있는 일시적 오류.
/// 스트림은 닫히지 않으며, 구독을 유지한 채 다음 배치로 복구됩니다.
class MarketFeedException implements Exception {
  const MarketFeedException(this.message);

  final String message;

  @override
  String toString() => 'MarketFeedException: $message';
}
