import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../domain/symbol_view.dart';
import '../search/chosung.dart';
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
  MarketStore(this._feed, {this.ownsFeed = true});

  final MarketFeed _feed;

  /// 이 스토어가 feed의 생명주기를 소유하는가.
  /// 벤치마크처럼 외부에서 feed를 주입/정리하는 경우 false.
  final bool ownsFeed;

  StreamSubscription<List<QuoteTick>>? _sub;

  // 정적 메타 + 기준값
  late final List<SymbolInfo> symbols;
  final Map<String, SymbolInfo> _infoByCode = {};
  final Map<String, double> _prevClose = {};
  final Map<String, int> _shares = {};

  // 초성 인덱스(이름 불변 → 1회 계산). code → "ㄱㅇㅈㅈ" 형태.
  final Map<String, String> _chosungByCode = {};

  // 실시간 상태 (정합성 처리 후)
  final Map<String, double> _price = {};
  final Map<String, int> _volume = {};
  final Map<String, int> _lastTs = {}; // 종목별 마지막 반영 timestampMs
  final Map<String, bool> _halted = {};

  // 행별 구독 대상 (종목당 1개).
  // 값은 "다시 그려라" 신호용 리빌드 카운터일 뿐, 데이터를 나르지 않는다.
  // 데이터는 행이 그릴 때 viewOf()로 라이브 상태에서 직접 읽는다 → 스크롤로
  // 새로 보이게 된 행도 항상 최신값으로 그려진다(신선도 유지).
  final Map<String, _RowSignal> _notifiers = {};

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

  // 검색/필터 상태.
  // _filtered == null  → 필터 없음(전체 2,000, 빠른 경로).
  // _filtered != null  → 통과한 종목 코드 목록(검색 결과 순서 = 원래 순서).
  List<String>? _filtered;
  String _query = '';

  /// 필터 "구조"가 바뀔 때(=목록 길이/구성 변경) 화면이 다시 빌드하도록 하는 신호.
  final ValueNotifier<int> filterVersion = ValueNotifier<int>(0);

  String get query => _query;

  /// 표시 중 종목 수 = 필터 통과 수(필터 없으면 전체).
  int get visibleCount => _filtered?.length ?? symbols.length;

  /// 화면 index → 종목 코드 (필터 유무에 따라 소스가 다름).
  String codeAt(int index) => _filtered?[index] ?? symbols[index].code;

  /// 화면 index → 종목명.
  String nameAt(int index) => _infoByCode[codeAt(index)]!.name;

  /// 행이 구독할 리빌드 신호. 값 자체는 의미 없다(바뀌면 rebuild).
  ValueListenable<int> notifierFor(String code) => _notifiers[code]!;

  /// 행이 그릴 때 호출. 라이브 상태에서 현재 뷰를 조립한다.
  SymbolView viewOf(String code) => SymbolView(
        price: _price[code]!,
        changePct: _pctOf(code),
        dayVolume: _volume[code]!,
        halted: _halted[code]!,
      );

  SymbolInfo infoAt(int index) => symbols[index];
  int get symbolCount => symbols.length;

  /// 스냅샷으로 초기 상태를 세우고 feed를 구독한다.
  ///
  /// [autoStart] 가 true면 feed.start()로 실시간 방출을 켠다(=앱 실행 경로).
  /// false면 구독만 걸고 방출은 외부의 pump()로 구동한다(=벤치마크 경로).
  void start({bool autoStart = true}) {
    _initFromSnapshot();
    _sub = _feed.ticks.listen(
      _onBatch,
      onError: _onError,
      cancelOnError: false, // 에러가 나도 구독을 유지한다
    );
    if (autoStart) _feed.start();
  }

  /// 벤치마크(pump) 경로: feed.start() 없이 구독만 건다.
  @visibleForTesting
  void attachForBenchmark() => start(autoStart: false);

  void _initFromSnapshot() {
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

      _chosungByCode[c] = chosungOf(e.info.name); // 이름 불변 → 1회만

      final pct = _pctOf(c);
      _treePct[c] = pct;
      _notifiers[c] = _RowSignal();
      _totalMarketCap += e.price * e.info.listedShares;
    }
    _ranked.addAll(symbols.map((s) => s.code));
    _recomputeAggregates();
  }

  /// 검색어 적용. 필터 집합을 새로 만들고 집계를 갱신한다.
  /// (debounce는 UI가 담당 — 여기선 한 번의 O(n) 스캔만 수행.)
  void setQuery(String raw) {
    final q = raw.trim();
    if (q == _query) return;
    _query = q;

    if (q.isEmpty) {
      _filtered = null;
    } else {
      final digit = hasDigit(q);
      final chosung = !digit && isChosungQuery(q);
      final result = <String>[];
      for (final s in symbols) {
        final code = s.code;
        final bool hit;
        if (digit) {
          hit = code.contains(q); // 종목코드 부분일치
        } else if (chosung) {
          hit = _chosungByCode[code]!.startsWith(q); // 초성 앞일치
        } else {
          hit = s.name.contains(q); // 완성형 이름 부분일치
        }
        if (hit) result.add(code);
      }
      _filtered = result;
    }

    filterVersion.value++; // 목록 구조 변경 → 화면 재빌드
    _recomputeAggregates(); // 틱이 없어도 시총·Top-20 즉시 갱신
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

      // (5) 바뀐 종목의 행만 rebuild 신호를 준다.
      //  + 꼬리 최적화: 화면에 보이는(리스너가 붙은) 행만 신호한다. 안 보이는 행은
      //    어차피 아무도 구독하지 않으므로 rebuild도, 뷰 객체 생성도 없다. 뷰(SymbolView)
      //    는 이제 flush가 아니라 행이 그릴 때 viewOf()로 만들어지므로, 큰 배치(최대
      //    250건) 프레임에서 안 보이는 ~240개 종목의 객체 할당이 통째로 사라진다.
      //    → worst/99th 프레임과 GC를 낮추는 게 목표. 스크롤로 나중에 보이게 된 행은
      //    그 시점에 viewOf()가 라이브 상태를 읽어 최신값으로 그린다(신선도 유지).
      final notifier = _notifiers[c]!;
      if (notifier.isWatched) notifier.bump();

      // (7) Top-20: pct가 바뀐 종목만 트리에서 빼고 다시 넣는다(전체 재정렬 X).
      if (_treePct[c] != pct) {
        _ranked.remove(c); // 트리는 아직 옛 pct 기준 → 제거가 정확히 동작
        _treePct[c] = pct;
        _ranked.add(c);
        topDirty = true;
      }
    }
    _dirty.clear();
    _recomputeAggregates(topDirty: topDirty);
  }

  /// 요약(시총·표시수)과 Top-20을 현재 필터 상태에 맞게 갱신한다.
  ///
  /// 판단(DESIGN.md에 명시): **필터가 걸리면 집계도 필터 집합 기준**이다
  /// (사용자가 보는 집합과 일치). 필터가 없으면 전체 기준의 빠른 경로를 쓴다.
  void _recomputeAggregates({bool topDirty = true}) {
    final filtered = _filtered;
    if (filtered == null) {
      // 빠른 경로: 전체 시총은 증분값, Top-20은 pct 변동 시에만 트리에서 재계산.
      summary.value =
          MarketSummary(count: symbols.length, totalMarketCap: _totalMarketCap);
      if (topDirty) topMovers.value = _computeTop20Full();
    } else {
      // 필터 경로: 통과 집합만 순회(크기에 비례, bounded). 시총 합계·Top-20 산출.
      var cap = 0.0;
      for (final c in filtered) {
        cap += _price[c]! * _shares[c]!;
      }
      summary.value =
          MarketSummary(count: filtered.length, totalMarketCap: cap);
      topMovers.value = _computeTop20Filtered(filtered);
    }
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

  /// 전체 기준 Top-20: SplayTreeSet의 앞에서 20개(트리가 이미 정렬 유지).
  List<TopMover> _computeTop20Full() {
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

  /// 필터 집합 기준 Top-20: 통과 집합을 등락률 내림차순 정렬해 상위 20(집합 크기에 비례).
  List<TopMover> _computeTop20Filtered(List<String> codes) {
    final sorted = [...codes]..sort((a, b) {
        final c = _pctOf(b).compareTo(_pctOf(a));
        return c != 0 ? c : a.compareTo(b);
      });
    final n = sorted.length < 20 ? sorted.length : 20;
    final out = <TopMover>[];
    for (var i = 0; i < n; i++) {
      final code = sorted[i];
      final info = _infoByCode[code]!;
      out.add(TopMover(
        code: code,
        name: info.name,
        changePct: _pctOf(code),
        price: _price[code]!,
        halted: _halted[code]!,
      ));
    }
    return out;
  }

  /// 테스트용: 프레임을 기다리지 않고 즉시 flush.
  @visibleForTesting
  void debugFlush() => _flush();

  /// 테스트용: 현재 종목 뷰 조회.
  @visibleForTesting
  SymbolView debugViewOf(String code) => viewOf(code);

  void dispose() {
    _sub?.cancel();
    if (ownsFeed) _feed.dispose(); // 주입된 feed는 소유자가 정리
    for (final n in _notifiers.values) {
      n.dispose();
    }
    summary.dispose();
    topMovers.dispose();
    error.dispose();
    filterVersion.dispose();
  }
}

/// 행의 rebuild 신호. 값(int)은 카운터일 뿐 데이터가 아니다.
/// [hasListeners]가 protected라 여기서 [isWatched]로 노출해, Store가 "화면에
/// 보이는(구독 중인) 행"만 골라 신호할 수 있게 한다(꼬리 최적화의 핵심).
class _RowSignal extends ValueNotifier<int> {
  _RowSignal() : super(0);

  /// 이 행이 현재 화면에 렌더 중(구독자 있음)인가.
  bool get isWatched => hasListeners;

  void bump() => value++;
}
