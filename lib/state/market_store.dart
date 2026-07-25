import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../domain/symbol_view.dart';
import '../seed/market_feed.dart';
import '../seed/market_models.dart';

/// feed와 UI 사이의 유일한 경계.
///
/// 책임:
///  1) 정합성  — timestampMs 가드로 역순 tick 폐기, dayVolume 단조 증가
///  2) 거래정지 — status 추적, 가격 고정, 파생값 판단
///  3) 스트림 에러 — 구독 유지하며 배너로 노출, 다음 배치에 자동 복구
///  4) Coalescing — 배치를 즉시 UI에 밀지 않고 "dirty 집합"에만 모아
///     프레임당 1회 flush (시간축 최소화)
///  5) rebuild 범위 축소 — 종목별 ValueNotifier로 "바뀐 행"만 갱신 (공간축 최소화)
///  6) 증분 집계 — 시총 합계는 델타로만 갱신 (전체 순회 X)
///  7) Top-20 라이브 랭킹 — SplayTreeSet로 dirty 종목만 재삽입 (전체 재정렬 X)
class MarketStore {
  MarketStore(this._feed);

  final MarketFeed _feed;
  StreamSubscription<List<QuoteTick>>? _sub;

  // 정적 메타 + 기준값
  late final List<SymbolInfo> symbols;
  final Map<String, SymbolInfo> _infoByCode = {};
  final Map<String, double> _prevClose = {};
  final Map<String, int> _shares = {};

  // 실시간 상태 (정합성 처리 후)
  final Map<String, double> _price = {};
  final Map<String, int> _volume = {};
  final Map<String, int> _lastTs = {}; // 종목별 마지막 반영 timestampMs
  final Map<String, bool> _halted = {};

  // 행별 구독 대상 (종목당 1개)
  final Map<String, ValueNotifier<SymbolView>> _notifiers = {};

  // Coalescing 버퍼: 이번 프레임에 바뀐 종목
  final Set<String> _dirty = {};
  bool _flushScheduled = false;

  // 증분 시총 합계
  double _totalMarketCap = 0;

  // Top-20 라이브 랭킹: 등락률 내림차순으로 전 종목 정렬 유지.
  // 트리에 반영된 pct는 _treePct에 따로 보관해 트리 불변식을 지킨다.
  final Map<String, double> _treePct = {};
  late final SplayTreeSet<String> _ranked = SplayTreeSet<String>(_compareByPctDesc);

  // 프레젠테이션이 구독하는 집계 notifier들 (행 rebuild와 격리)
  final ValueNotifier<MarketSummary> summary =
      ValueNotifier(const MarketSummary(count: 0, totalMarketCap: 0));
  final ValueNotifier<List<TopMover>> topMovers =
      ValueNotifier(const <TopMover>[]);
  final ValueNotifier<String?> error = ValueNotifier<String?>(null);

  ValueNotifier<SymbolView> notifierFor(String code) => _notifiers[code]!;
  SymbolInfo infoAt(int index) => symbols[index];
  int get symbolCount => symbols.length;

  /// 스냅샷으로 초기 상태를 세우고, feed 구독을 시작한다.
  void start() {
    symbols = _feed.symbols;
    for (final e in _feed.initialSnapshot()) {
      final c = e.info.code;
      _infoByCode[c] = e.info;
      _prevClose[c] = e.previousClose;
      _shares[c] = e.info.listedShares;
      _price[c] = e.price;
      _volume[c] = e.dayVolume;
      _lastTs[c] = -1;
      _halted[c] = false;

      final pct = _pctOf(c);
      _treePct[c] = pct;
      _notifiers[c] = ValueNotifier(
        SymbolView(price: e.price, changePct: pct, dayVolume: e.dayVolume, halted: false),
      );
      _totalMarketCap += e.price * e.info.listedShares;
    }
    _ranked.addAll(symbols.map((s) => s.code));
    summary.value =
        MarketSummary(count: symbols.length, totalMarketCap: _totalMarketCap);
    topMovers.value = _computeTop20();

    _sub = _feed.ticks.listen(
      _onBatch,
      onError: _onError,
      cancelOnError: false, // 에러가 나도 구독을 유지한다
    );
    _feed.start();
  }

  /// 벤치마크(pump) 경로: feed.start() 없이 구독만 건다.
  void attachForBenchmark() {
    symbols = _feed.symbols;
    // start()의 초기화 로직을 재사용하되 feed.start()는 부르지 않는다.
    // (여기서는 간결히 start()와 동일 초기화만 수행)
    for (final e in _feed.initialSnapshot()) {
      final c = e.info.code;
      _infoByCode[c] = e.info;
      _prevClose[c] = e.previousClose;
      _shares[c] = e.info.listedShares;
      _price[c] = e.price;
      _volume[c] = e.dayVolume;
      _lastTs[c] = -1;
      _halted[c] = false;
      final pct = _pctOf(c);
      _treePct[c] = pct;
      _notifiers[c] = ValueNotifier(
        SymbolView(price: e.price, changePct: pct, dayVolume: e.dayVolume, halted: false),
      );
      _totalMarketCap += e.price * e.info.listedShares;
    }
    _ranked.addAll(symbols.map((s) => s.code));
    summary.value =
        MarketSummary(count: symbols.length, totalMarketCap: _totalMarketCap);
    topMovers.value = _computeTop20();
    _sub = _feed.ticks.listen(_onBatch, onError: _onError, cancelOnError: false);
  }

  void _onError(Object e, StackTrace _) {
    // 구독은 살아있다. 배너로만 알리고, 다음 성공 배치에서 자동 해제한다.
    error.value = e is MarketFeedException ? e.message : e.toString();
  }

  void _onBatch(List<QuoteTick> batch) {
    if (error.value != null) error.value = null; // 다음 배치 도착 = 복구

    for (final t in batch) {
      final c = t.code;

      // (1) 가격/상태: timestampMs 가드. 도착 순서가 아니라 관측 시각이 진실.
      final lastTs = _lastTs[c] ?? -1;
      if (t.timestampMs > lastTs) {
        _lastTs[c] = t.timestampMs;
        final old = _price[c]!;
        if (t.price != old) {
          // (6) 증분 시총: 전체 순회 없이 델타만 더한다.
          _totalMarketCap += (t.price - old) * _shares[c]!;
          _price[c] = t.price;
        }
        _halted[c] = t.status == QuoteStatus.halted;
        _dirty.add(c);
      }
      // 역순 tick이면 위 블록을 건너뛰어 가격이 과거로 되돌아가지 않는다.

      // (2) 거래량: 누적값이므로 timestampMs와 무관하게 max로 단조 증가 유지.
      final vol = _volume[c] ?? 0;
      if (t.dayVolume > vol) {
        _volume[c] = t.dayVolume;
        _dirty.add(c);
      }
    }

    _scheduleFlush();
  }

  /// (4) Coalescing: 프레임당 1회만 flush 예약. 이미 예약돼 있으면 무시.
  void _scheduleFlush() {
    if (_flushScheduled) return;
    _flushScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) => _flush());
    SchedulerBinding.instance.scheduleFrame();
  }

  void _flush() {
    _flushScheduled = false;
    if (_dirty.isEmpty) return;

    var topDirty = false;
    for (final c in _dirty) {
      final pct = _pctOf(c);

      // (5) 바뀐 종목의 notifier만 갱신 → 보이는 그 행만 rebuild.
      _notifiers[c]!.value = SymbolView(
        price: _price[c]!,
        changePct: pct,
        dayVolume: _volume[c]!,
        halted: _halted[c]!,
      );

      // (7) Top-20: pct가 바뀐 종목만 트리에서 빼고 다시 넣는다(전체 재정렬 X).
      if (_treePct[c] != pct) {
        _ranked.remove(c); // 트리는 아직 옛 pct 기준 → 제거가 정확히 동작
        _treePct[c] = pct;
        _ranked.add(c);
        topDirty = true;
      }
    }
    _dirty.clear();

    summary.value =
        MarketSummary(count: symbols.length, totalMarketCap: _totalMarketCap);
    if (topDirty) topMovers.value = _computeTop20();
  }

  double _pctOf(String code) {
    final base = _prevClose[code]!;
    if (base == 0) return 0;
    return (_price[code]! - base) / base * 100;
  }

  int _compareByPctDesc(String a, String b) {
    if (a == b) return 0;
    final pa = _treePct[a] ?? 0;
    final pb = _treePct[b] ?? 0;
    final c = pb.compareTo(pa); // 내림차순
    return c != 0 ? c : a.compareTo(b); // 동률은 코드로 안정 정렬
  }

  List<TopMover> _computeTop20() {
    final out = <TopMover>[];
    for (final c in _ranked) {
      final info = _infoByCode[c]!;
      out.add(TopMover(
        code: c,
        name: info.name,
        changePct: _treePct[c]!,
        price: _price[c]!,
        halted: _halted[c]!,
      ));
      if (out.length >= 20) break;
    }
    return out;
  }

  /// 테스트용: 프레임을 기다리지 않고 즉시 flush.
  @visibleForTesting
  void debugFlush() => _flush();

  /// 테스트용: 현재 종목 뷰 조회.
  @visibleForTesting
  SymbolView debugViewOf(String code) => _notifiers[code]!.value;

  void dispose() {
    _sub?.cancel();
    _feed.dispose();
    for (final n in _notifiers.values) {
      n.dispose();
    }
    summary.dispose();
    topMovers.dispose();
    error.dispose();
  }
}
