import 'dart:async';

// Float64List/Int32List는 foundation이 dart:typed_data를 재수출해 함께 들어온다.
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
///  7) Top-20 라이브 랭킹 — 등락률을 Float64List에 O(1) 갱신 + 20슬롯 선형 선택
class MarketStore {
  MarketStore(this._feed, {this.ownsFeed = true});

  // 데이터 흐름 feed
  final MarketFeed _feed;

  /// 이 스토어가 feed의 생명주기를 소유하는가.
  /// 벤치마크처럼 외부에서 feed를 주입/정리하는 경우 false.
  final bool ownsFeed;

  /// feed 구독 핸들. 데이터가 아니라 "연결"을 들고 있는 값이다.
  ///
  /// - `List<QuoteTick>`: 피드는 tick 하나씩이 아니라 배치 단위로 방출한다.
  /// - `?`: start() 전에는 구독이 없다(생성자에서 만들 수 없어 nullable).
  /// - listen()의 반환값을 버리면 다시는 끊을 수 없다. 그러면 스트림이 store를
  ///   계속 붙잡아 GC되지 않고, dispose된 notifier를 두드려 크래시한다.
  ///   → 반드시 dispose()의 `_sub?.cancel()`과 짝을 이룬다.
  ///
  /// 상세 화면의 목록 pause(_listPaused)와는 다른 층이다. 그쪽은 구독을 건드리지
  /// 않고 알림만 멈추므로 tick은 계속 받아 상태가 최신으로 유지된다.
  /// 여기서 pause()를 썼다면 tick 자체를 놓쳐 복귀 시 데이터에 구멍이 생긴다.
  StreamSubscription<List<QuoteTick>>? _sub;

  // 정적 메타 + 기준값
  late final List<SymbolInfo> symbols; // 종목 정보
  final Map<String, SymbolInfo> _infoByCode = {}; // 종목 코드에 대응하는 종목정보 (단일값)
  final Map<String, double> _prevClose = {}; // 종목별 전일 종가(previous close)
  final Map<String, int> _shares = {}; // 종목별 상장 주식 수

  // 초성 인덱스(이름 불변 → 1회 계산). code → "ㄱㅇㅈㅈ" 형태.
  final Map<String, String> _chosungByCode = {};

  // 실시간 상태 (정합성 처리 후)
  final Map<String, double> _price = {}; // 현재 체결가(역순 tick은 반영 안 함)
  final Map<String, int> _volume = {}; // 누적 거래량(max로만 갱신 → 단조 증가)
  final Map<String, int> _lastTs = {}; // 종목별 마지막 반영 timestampMs (역순 tick 가드 기준)
  final Map<String, bool> _halted = {}; // 거래정지 여부(status == halted)

  // 상세 화면용 파생값. tick 흐름에서 누적(전 종목 O(1) 추적, 비용 미미).
  final Map<String, double> _open = {}; // 구독 시점가(=시가 성격)
  final Map<String, double> _high = {}; // 구독 이후 최고가(tick마다 max로 누적)
  final Map<String, double> _low = {}; // 구독 이후 최저가(tick마다 min으로 누적)

  // 상세 화면 수명 관리.
  String? _focusedCode; // 현재 상세로 보고 있는 종목(없으면 null)
  bool _listPaused = false; // 상세가 떠 있는 동안 목록 갱신을 멈춘다
  final List<double> _spark = []; // 포커스 종목의 최근 체결가(링버퍼)
  static const int _sparkCap = 60;

  // 행별 구독 대상 (종목당 1개).
  // 값은 "다시 그려라" 신호용 리빌드 카운터일 뿐, 데이터를 나르지 않는다.
  // 데이터는 행이 그릴 때 viewOf()로 라이브 상태에서 직접 읽는다 → 스크롤로
  // 새로 보이게 된 행도 항상 최신값으로 그려진다(신선도 유지).
  final Map<String, _RowSignal> _notifiers = {};

  // Coalescing "무엇을": 이번 프레임에 값이 바뀐 종목 코드 모음.
  // tick마다 UI를 갱신하지 않고 여기에 add만 해두었다가, flush에서 한꺼번에
  // 처리한다. Set이라 한 프레임에 같은 종목이 여러 번 바뀌어도 1번만 처리(중복 제거).
  final Set<String> _dirty = {};

  // Coalescing "언제": 이번 프레임에 flush를 이미 예약했는가(중복 예약 방지 잠금).
  // _scheduleFlush가 배치마다 불려도 첫 호출만 콜백을 걸고 true로 잠근다.
  // _flush 진입 시 false로 풀려 다음 프레임에 다시 예약할 수 있다.
  // → _dirty(무엇을)와 짝을 이뤄 "프레임당 flush 정확히 1회"를 보장.
  bool _flushScheduled = false;

  // 증분 시총 합계
  double _totalMarketCap = 0;

  // Top-20 라이브 랭킹.
  //
  // 설계 근거(PERF.md §5): 이전에는 SplayTreeSet을 등락률 내림차순으로 유지하며
  // pct가 바뀐 종목만 remove→add 했다(O(dirty·log n)). 실측(perf/top20_bench.dart)
  // 결과 이 구조가 **상수 인자에서 36배 졌다**: 175us/프레임 → 4.8us/프레임.
  //
  // 빅오가 아니라 상수가 원인이라는 점이 중요하다. 트리가 유리한 조건은
  //   dirty · log₂n < n  →  dirty < 2000/11 ≈ 182
  // 인데 실제 dirty는 평균 100(p90 182, max 214)이라 **대부분의 프레임에서 트리가
  // 빅오상 유리한 쪽**이었다. 그런데도 진 이유는 프레임당 비교자 호출 4,477회이고
  // 그 한 번마다 `_treePct` 해시 조회 2회 + 박싱 double 비교가 붙으며, 트리 노드
  // 순회가 포인터 추적(캐시 미스)이기 때문이다.
  //
  // 그래서 "인덱스로 O(1) 갱신 + 연속 메모리 선형 선택"으로 바꿨다:
  //  - 갱신: dirty 종목의 pct를 Float64List 한 칸에 쓴다 (log n 소멸)
  //  - 선택: 전체를 한 번 훑어 20슬롯만 유지 (_topK) — 깨질 불변식이 없다
  // symbols는 스냅샷 이후 불변이므로 "인덱스 i ↔ symbols[i].code"가 안정적이다.
  //
  // 실기기 검증에서 더 큰 소득은 **할당 제거**였다(PERF.md §5.5). 이전 구조는 프레임당
  // 두 종류를 할당했다 — Map<String,double>에 넣는 double은 박싱되고, SplayTreeSet.add는
  // 노드를 새로 만든다(remove+add 쌍이라 매번). dirty 100 × 2종 × 636프레임 ≈ 12만 개.
  // Float64List는 언박싱 저장이라 할당이 0이다. 그 결과 old-gen GC 회귀(+71%)가 ±0%로,
  // young-gen GC 개선폭이 −26%에서 −54%로 바뀌었다.
  //
  // 반면 **프레임 타임 꼬리(99th/worst)는 개선되지 않았다.** 꼬리의 주범은 랭킹 계산이
  // 아니라 Top-20 카드·행의 위젯 rebuild다(PERF.md §5.5 ②). 여기를 더 깎아도 꼬리는
  // 움직이지 않으니, 다음 작업은 카드 diff 쪽이다.
  final Map<String, int> _indexOf = {}; // code → symbols 내 고정 인덱스
  late final Float64List _pct; // 인덱스별 등락률(flush 시점 스냅샷)

  static const int _topCount = 20;

  // 프레젠테이션이 구독하는 집계 notifier들 (행 rebuild와 격리)
  final ValueNotifier<MarketSummary> summary = ValueNotifier(
    const MarketSummary(count: 0, totalMarketCap: 0),
  );
  final ValueNotifier<List<TopMover>> topMovers = ValueNotifier(
    const <TopMover>[],
  );
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

  // ── 상세 화면 수명 관리 ────────────────────────────────────────────────
  /// 상세 진입: 이 종목만 갱신하고 목록 갱신은 멈춘다. 스파크라인 기록 시작.
  void openDetail(String code) {
    _focusedCode = code;
    _listPaused = true;
    _spark
      ..clear()
      ..add(_price[code]!); // 현재가 1점으로 시작
  }

  /// 상세 종료: 목록 갱신 재개 + 그동안의 변화를 반영하도록 강제 새로고침.
  void closeDetail() {
    _focusedCode = null;
    _listPaused = false;
    _spark.clear();
    // offstage였던 목록 위젯들은 마지막 빌드 상태로 멈춰 있으므로, 보이는 행과
    // 집계를 한 번 깨워 현재 상태로 맞춘다.
    for (final n in _notifiers.values) {
      if (n.isWatched) n.bump(); // 현재 보이는 행만 깨워 최신 상태로 다시 그린다
    }
    _recomputeAggregates(); // 요약·Top-20도 현재 상태로 재계산
  }

  /// 상세 뷰 조립(라이브 상태 + 누적 파생값 + 스파크라인 스냅샷).
  DetailView detailOf(String code) {
    final info = _infoByCode[code]!;
    final price = _price[code]!;
    final prev = _prevClose[code]!;
    return DetailView(
      code: code,
      name: info.name,
      price: price,
      previousClose: prev,
      changeAbs: price - prev,
      changePct: _pctOf(code),
      open: _open[code]!,
      high: _high[code]!,
      low: _low[code]!,
      dayVolume: _volume[code]!,
      halted: _halted[code]!,
      spark: List<double>.of(_spark), // 스냅샷 복사(그리는 쪽과 분리)
    );
  }

  /// 스냅샷으로 초기 상태를 세우고 feed를 구독한다.
  ///
  /// [autoStart] 가 true면 feed.start()로 실시간 방출을 켠다(=앱 실행 경로).
  /// false면 구독만 걸고 방출은 외부의 pump()로 구동한다(=벤치마크 경로).
  void start({bool autoStart = true}) {
    _initFromSnapshot();
    _sub = _feed.ticks.listen(
      _onBatch,
      onError: _onError,
      // 기본값 true면 에러 한 번에 구독이 자동 취소되어 피드가 영영 끊긴다.
      // 이 앱은 일시적 지연을 배너로 알리고 회복해야 하므로 구독을 유지한다.
      cancelOnError: false, // 에러가 나도 구독을 유지한다
    );
    if (autoStart) _feed.start();
  }

  /// 벤치마크(pump) 경로: feed.start() 없이 구독만 건다.
  @visibleForTesting
  void attachForBenchmark() => start(autoStart: false);

  void _initFromSnapshot() {
    symbols = _feed.symbols; // 표시 순서 확정(이후 불변)

    // 랭킹용 인덱스 축을 먼저 세운다. 스냅샷 순회 순서가 symbols 순서와 같다는
    // 보장이 없으므로, 인덱스는 반드시 symbols(표시 순서)를 기준으로 매긴다.
    for (var i = 0; i < symbols.length; i++) {
      _indexOf[symbols[i].code] = i;
    }
    _pct = Float64List(symbols.length);

    for (final e in _feed.initialSnapshot()) {
      final c = e.info.code;
      _infoByCode[c] = e.info; // 정적 메타 등록
      _prevClose[c] = e.previousClose; // 등락률·등락액의 기준선
      _shares[c] = e.info.listedShares; // 시총 계산용 주식수
      _price[c] = e.price; // 초기 현재가 = 스냅샷 가격
      _volume[c] = e.dayVolume; // 초기 누적 거래량
      _lastTs[c] = -1; // 아직 tick 없음 → 어떤 timestamp든 통과하도록 -1
      _halted[c] = false; // 시작은 정상 거래
      _open[c] = e.price; // 구독 시점가를 시가로 삼는다
      _high[c] = e.price; // 고가/저가 시작점 = 현재가
      _low[c] = e.price;

      _chosungByCode[c] = chosungOf(e.info.name); // 이름 불변 → 1회만

      _pct[_indexOf[c]!] = _pctOf(c); // 초기 등락률을 랭킹 배열에 채운다
      _notifiers[c] = _RowSignal(); // 행별 rebuild 신호 준비
      _totalMarketCap += e.price * e.info.listedShares; // 증분 시총 초기 누적
    }
    _recomputeAggregates(); // 첫 요약·Top-20 산출
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

  /// **동기 유지 필수.** Dart 코드는 UI 아이솔레이트 하나에서 돌기 때문에, 이 함수가
  /// 동기인 동안에는 루프 중간에 프레임이 끼어들 수 없다 → 가격만 갱신되고 시총 합계는
  /// 아직인 "찢어진 상태"가 UI에 노출될 경로가 없다(그래서 락이 없어도 안전하다).
  /// async/await를 넣으면 ① 배치 절반만 반영된 상태로 flush가 돌고
  /// ② _dirty가 두 프레임에 쪼개져 coalescing 불변식이 깨진다.
  void _onBatch(List<QuoteTick> batch) {
    if (error.value != null) error.value = null; // 다음 배치 도착 = 복구

    for (final t in batch) {
      final c = t.code;

      // (1) 가격/상태: timestampMs 가드. 도착 순서가 아니라 관측 시각이 진실.
      final lastTs = _lastTs[c] ?? -1;

      // 마지막 관측 timestamps보다 이후에 온 최신 데이터라면
      if (t.timestampMs > lastTs) {
        // timestamp를 현재로 갱신
        _lastTs[c] = t.timestampMs;
        final old = _price[c]!;
        // 가격이 변했다면
        if (t.price != old) {
          // (6) 증분 시총: 전체 순회 없이 델타만 더한다.
          _totalMarketCap += (t.price - old) * _shares[c]!;
          _price[c] = t.price;
          if (t.price > _high[c]!) _high[c] = t.price; // 고가 누적
          if (t.price < _low[c]!) _low[c] = t.price; // 저가 누적
        }
        _halted[c] = t.status == QuoteStatus.halted;
        _dirty.add(c); // 값이 변한 종목으로 추가

        // 상세로 보고 있는 종목이면 스파크라인 링버퍼에 체결가 추가.
        if (c == _focusedCode) {
          _spark.add(_price[c]!);
          if (_spark.length > _sparkCap) _spark.removeAt(0);
        }
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
    if (_flushScheduled) return; // 이번 프레임에 이미 예약됨 → 중복 예약 방지
    _flushScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback(
      (_) => _flush(),
    ); // 이번 프레임이 끝난 뒤 1회만 flush
    SchedulerBinding.instance.scheduleFrame(); // 유휴 상태여도 프레임을 깨워 flush 보장
  }

  void _flush() {
    _flushScheduled = false;
    if (_dirty.isEmpty) return;

    var topDirty = false;
    for (final c in _dirty) {
      final pct = _pctOf(c); // 등락률 계산

      // (5) 바뀐 종목의 행만 rebuild 신호를 준다.
      //  + 꼬리 최적화: 화면에 보이는(리스너가 붙은) 행만 신호한다. 안 보이는 행은
      //    어차피 아무도 구독하지 않으므로 rebuild도, 뷰 객체 생성도 없다. 뷰(SymbolView)
      //    는 이제 flush가 아니라 행이 그릴 때 viewOf()로 만들어지므로, 큰 배치(최대
      //    250건) 프레임에서 안 보이는 ~240개 종목의 객체 할당이 통째로 사라진다.
      //    → worst/99th 프레임과 GC를 낮추는 게 목표. 스크롤로 나중에 보이게 된 행은
      //    그 시점에 viewOf()가 라이브 상태를 읽어 최신값으로 그린다(신선도 유지).
      final notifier = _notifiers[c]!;
      // 상세가 떠 있으면(_listPaused) 포커스 종목만 신호 → 목록의 불필요한 rebuild 제거.
      // 트리 갱신은 계속해 복귀 시 랭킹이 정확하도록 한다.
      if (notifier.isWatched && (!_listPaused || c == _focusedCode)) {
        notifier.bump();
      }

      // (7) Top-20: pct가 바뀐 종목의 배열 한 칸만 덮어쓴다(O(1), 정렬 자료구조 없음).
      // 순서는 여기서 유지하지 않는다 — 선택은 아래 _topK의 선형 스캔이 담당한다.
      final i = _indexOf[c]!;
      if (_pct[i] != pct) {
        _pct[i] = pct;
        topDirty = true;
      }
    }
    _dirty.clear();
    // 상세가 떠 있는 동안은 목록의 요약·Top-20 위젯이 offstage이므로 갱신 생략.
    if (!_listPaused) _recomputeAggregates(topDirty: topDirty);
  }

  /// 요약(시총·표시수)과 Top-20을 현재 필터 상태에 맞게 갱신한다.
  ///
  /// 판단(DESIGN.md에 명시): **필터가 걸리면 집계도 필터 집합 기준**이다
  /// (사용자가 보는 집합과 일치). 필터가 없으면 전체 기준의 빠른 경로를 쓴다.
  void _recomputeAggregates({bool topDirty = true}) {
    final filtered = _filtered;
    if (filtered == null) {
      // 빠른 경로: 전체 시총은 증분값, Top-20은 pct 변동 시에만 트리에서 재계산.
      summary.value = MarketSummary(
        count: symbols.length,
        totalMarketCap: _totalMarketCap,
      );
      if (topDirty) topMovers.value = _topK();
    } else {
      // 필터 경로: 통과 집합만 순회(크기에 비례, bounded). 시총 합계·Top-20 산출.
      var cap = 0.0;
      for (final c in filtered) {
        cap += _price[c]! * _shares[c]!;
      }
      summary.value = MarketSummary(
        count: filtered.length,
        totalMarketCap: cap,
      );
      topMovers.value = _topK(filtered);
    }
  }

  double _pctOf(String code) {
    final base = _prevClose[code]!; // 기준 = 전일 종가
    if (base == 0) return 0; // 0 나눗셈 가드(기준가 없으면 변동 0 취급)
    return (_price[code]! - base) / base * 100; // (현재가 - 기준) / 기준 → %
  }

  /// 등락률 상위 [_topCount]를 **한 번의 선형 스캔**으로 고른다.
  /// [scope]가 null이면 전체 기준, 아니면 필터 통과 집합 기준(전체/필터 경로 공용).
  ///
  /// 정렬(O(m log m))이 아니라 **k슬롯 삽입 선택**(O(m))이다:
  ///  - `floor`(현재 k위의 pct)보다 낮은 후보는 비교 1회로 즉시 탈락 → 2,000개
  ///    대부분이 여기서 끝난다.
  ///  - 통과한 소수만 크기 20 배열에서 자리를 찾아 뒤로 밀어낸다(이동 상한 20).
  ///  - pct는 Float64List·후보는 Int32List로 들고 있어 순회가 **연속 메모리**다.
  ///    비교마다 해시 조회가 붙던 트리 비교자와의 상수 차이가 여기서 난다.
  ///
  /// 동률 처리: 엄격 부등호(`<`)로만 밀어내므로 **먼저 훑은 쪽이 앞선다**. 스캔
  /// 순서는 `symbols`(표시 순서, 불변) 기준이라 결과는 결정론적이다. 이 피드의
  /// 코드는 `000001`부터 증가하며 발급되므로 종전의 "동률은 코드 오름차순"과
  /// 동일한 순서가 나온다.
  List<TopMover> _topK([List<String>? scope]) {
    final m = scope?.length ?? symbols.length;
    final k = m < _topCount ? m : _topCount;
    if (k == 0) return const <TopMover>[];

    final topIdx = Int32List(k); // 상위 k의 종목 인덱스 (pct 내림차순)
    final topPct = Float64List(k); // 그 pct 값 (비교용, 재조회 없음)
    var filled = 0;
    var floor = double.negativeInfinity; // k칸이 찰 때까지는 누구도 탈락시키지 않는다

    for (var s = 0; s < m; s++) {
      // 전체 경로는 인덱스가 곧 스캔 위치. 필터 경로만 code → 인덱스 조회 1회.
      final i = scope == null ? s : _indexOf[scope[s]]!;
      final p = _pct[i];
      if (filled == k && p <= floor) continue; // 대부분 여기서 탈락

      var q = filled < k ? filled : k - 1; // 꽉 찼으면 최하위 칸을 덮어쓴다
      while (q > 0 && topPct[q - 1] < p) {
        topPct[q] = topPct[q - 1]; // 자기보다 낮은 것들을 뒤로 밀어낸다
        topIdx[q] = topIdx[q - 1];
        q--;
      }
      topPct[q] = p;
      topIdx[q] = i;
      if (filled < k) filled++;
      if (filled == k) floor = topPct[k - 1]; // 경계값 갱신
    }

    final out = <TopMover>[];
    for (var r = 0; r < filled; r++) {
      final info = symbols[topIdx[r]]; // 인덱스로 바로 메타 접근(_infoByCode 조회 불필요)
      final code = info.code;
      out.add(
        TopMover(
          code: code,
          name: info.name,
          changePct: topPct[r], // 선택에 쓰인 값 그대로(표시와 순서가 어긋나지 않는다)
          price: _price[code]!,
          halted: _halted[code]!,
        ),
      );
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
    // `?.`인 이유: start() 없이 dispose될 수 있다(구독 전 화면 이탈).
    // 아래 notifier들을 dispose하기 전에 먼저 끊어야 _onBatch가 죽은 notifier를
    // 건드리지 않는다(순서가 중요).
    _sub?.cancel(); // feed 구독 해제(더 이상 batch 안 받음)
    if (ownsFeed) _feed.dispose(); // 주입된 feed는 소유자가 정리
    for (final n in _notifiers.values) {
      n.dispose(); // 행별 notifier 전부 정리(리스너 누수 방지)
    }
    summary.dispose(); // 집계 notifier들도 정리
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
