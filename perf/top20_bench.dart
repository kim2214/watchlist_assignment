// 콘솔 벤치마크 스크립트다. 결과 출력이 목적이므로 print를 쓴다(앱 코드 아님).
// ignore_for_file: avoid_print

// Top-20 랭킹 자료구조 A/B 벤치마크 — PERF.md §5 의 근거 데이터.
//
// 실행:
//   dart run perf/top20_bench.dart
//   dart compile exe perf/top20_bench.dart -o /tmp/bench && /tmp/bench   # AOT 권장
//
// 무엇을 재는가
//   실제 `MarketFeed`(기본 seed=20260703)에서 600배치를 받아, 각 프레임의
//   "(dirty 종목, 갱신된 등락률)" 목록을 **한 번만** 만들어 둔다. 그리고 그
//   동일한 입력을 두 랭킹 전략에 흘려 **랭킹 갱신 + 상위 20 선택** 비용만 잰다.
//
//   A) SplayTreeSet<String> + _treePct  (2026-08-06 이전 구현)
//   B) Float64List + 20슬롯 선형 선택    (현재 구현: market_store.dart _topK)
//
//   가격 갱신·dirty Set 구성 같은 **두 전략의 공통 비용은 측정에서 제외**했다.
//   비교 대상이 자료구조 선택이므로, 공통항을 넣으면 차이가 희석될 뿐이다.
//
// 왜 마이크로 벤치마크인가
//   실기기 프레임 타임(PERF.md §결과)은 build/layout/raster가 섞여 랭킹 비용만
//   분리해 보기 어렵다. 이 벤치는 랭킹만 떼어내 "어디서 몇 us가 나오는지"를
//   보여주는 용도다. 두 측정은 대체가 아니라 보완 관계다.
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:watchlist_assignment/seed/market_feed.dart';
import 'package:watchlist_assignment/seed/market_models.dart';

const int kFrames = 600; // 60Hz × 10초 (perf_test.dart와 동일)
const int kTop = 20;

Future<void> main() async {
  final frames = await _recordFrames();

  // dirty 분포를 먼저 보여준다. "공칭 최대 250건"이 아니라 **실제로 등락률이
  // 바뀌는 종목 수**가 교차점 논증의 입력이기 때문이다(중복 tick·호가 단위
  // 반올림으로 실제 값은 공칭보다 훨씬 작다).
  final n = frames.first.n;
  final counts = (frames.map((f) => f.codes.length).toList())..sort();
  int q(double p) => counts[(counts.length * p).clamp(0, counts.length - 1).toInt()];
  final crossover = n / _log2(n);
  final over = counts.where((c) => c > crossover).length;

  print('입력: $kFrames 프레임 (실제 MarketFeed, seed 20260703)');
  print('dirty(등락률이 바뀐 종목) 분포: '
      'avg ${(counts.reduce((a, b) => a + b) / kFrames).toStringAsFixed(1)}  '
      'p50 ${q(0.50)}  p90 ${q(0.90)}  p99 ${q(0.99)}  max ${counts.last}');
  print('교차점: dirty·log₂n < n  →  dirty < $n/${_log2(n).toStringAsFixed(0)} '
      '≈ ${crossover.toStringAsFixed(0)}');
  print('  → 교차점을 넘는 프레임: $over/$kFrames '
      '(${(over * 100 / kFrames).toStringAsFixed(1)}%) '
      '— 나머지 프레임에서는 트리가 빅오상 유리한 쪽이다');
  print('');

  // 2회 돌려 JIT 워밍업 후 두 번째만 채택(AOT에서도 캐시 워밍업 효과가 있다).
  late _Run a, b;
  for (var round = 0; round < 2; round++) {
    a = _runSplayTree(frames);
    b = _runLinearScan(frames);
  }

  _report('A) SplayTreeSet (before)', a);
  _report('B) 선형 스캔 (after)', b);
  print('');
  print('배수: avg ${(a.avg / b.avg).toStringAsFixed(1)}x  '
      'worst ${(a.worst / b.worst).toStringAsFixed(1)}x');
  print('비교자 호출: A ${a.comparisons ~/ kFrames} 회/프레임 → B 0 회 '
      '(비교자 자체가 없다)');

  // 등가성 검증: 두 전략의 프레임별 Top-20이 완전히 같아야 한다.
  var mismatch = -1;
  for (var f = 0; f < kFrames; f++) {
    if (a.top[f].join(',') != b.top[f].join(',')) {
      mismatch = f;
      break;
    }
  }
  print('');
  print(mismatch < 0
      ? '✅ 등가성: 600프레임 전부 Top-20 동일 (코드·순서)'
      : '❌ 등가성 위반: 프레임 $mismatch 에서 결과가 갈림');
}

/// log₂(n). 트리 연산이 훑는 깊이 ≈ 이 값이라 교차점 계산의 분모가 된다.
double _log2(int n) {
  var v = 1, bits = 0;
  while (v < n) {
    v <<= 1;
    bits++;
  }
  return bits.toDouble();
}

// ── 입력 녹화: 실제 피드 tick → 프레임별 (dirty 종목, 새 등락률) ─────────────

class _Frame {
  _Frame(this.codes, this.pcts, this.n);
  final List<String> codes; // 이 프레임에 등락률이 바뀐 종목
  final Float64List pcts; // 그 종목의 갱신 후 등락률
  final int n; // 전체 종목 수
}

Future<List<_Frame>> _recordFrames() async {
  final feed = MarketFeed();
  final symbols = feed.symbols;
  final prevClose = <String, double>{};
  final price = <String, double>{};
  final lastTs = <String, int>{};
  final livePct = <String, double>{}; // 마지막으로 랭킹에 반영된 등락률

  for (final e in feed.initialSnapshot()) {
    final c = e.info.code;
    prevClose[c] = e.previousClose;
    price[c] = e.price;
    lastTs[c] = -1;
  }
  double pctOf(String c) {
    final base = prevClose[c]!;
    return base == 0 ? 0 : (price[c]! - base) / base * 100;
  }

  for (final s in symbols) {
    livePct[s.code] = pctOf(s.code);
  }

  final frames = <_Frame>[];
  final batches = <List<QuoteTick>>[];
  // 이 벤치는 정합성 검증이 아니라 랭킹 비용 측정이므로 일시 에러는 무시한다.
  final sub = feed.ticks.listen(batches.add, onError: (Object _, StackTrace _) {});

  for (var f = 0; f < kFrames; f++) {
    batches.clear();
    feed.pump(1);
    await Future<void>.delayed(Duration.zero); // broadcast 전달 대기

    // market_store._onBatch 와 동일한 정합성 가드(역순 tick 폐기).
    final dirty = <String>{};
    for (final batch in batches) {
      for (final t in batch) {
        final c = t.code;
        if (t.timestampMs > (lastTs[c] ?? -1)) {
          lastTs[c] = t.timestampMs;
          if (t.price != price[c]) {
            price[c] = t.price;
            dirty.add(c);
          }
        }
      }
    }

    // market_store._flush 와 동일하게 "pct가 실제로 바뀐 종목"만 남긴다.
    final codes = <String>[];
    final pcts = <double>[];
    for (final c in dirty) {
      final p = pctOf(c);
      if (livePct[c] != p) {
        livePct[c] = p;
        codes.add(c);
        pcts.add(p);
      }
    }
    frames.add(_Frame(codes, Float64List.fromList(pcts), symbols.length));
  }

  await sub.cancel();
  feed.dispose();
  return frames;
}

// ── 측정 결과 ──────────────────────────────────────────────────────────────

class _Run {
  _Run(this.samples, this.top, this.comparisons);
  final Float64List samples; // 프레임별 소요(us)
  final List<List<String>> top; // 프레임별 Top-20 코드
  final int comparisons; // 비교자 호출 총 횟수(A만 의미 있음)

  double get avg => samples.reduce((x, y) => x + y) / samples.length;
  double get worst => samples.reduce((x, y) => x > y ? x : y);
  double pct(double q) {
    final s = samples.toList()..sort();
    return s[(s.length * q).clamp(0, s.length - 1).toInt()];
  }
}

void _report(String label, _Run r) {
  print('${label.padRight(26)} '
      'avg ${r.avg.toStringAsFixed(1)}us  '
      'p50 ${r.pct(0.50).toStringAsFixed(0)}  '
      'p90 ${r.pct(0.90).toStringAsFixed(0)}  '
      'p99 ${r.pct(0.99).toStringAsFixed(0)}  '
      'worst ${r.worst.toStringAsFixed(0)}');
}

// ── A) 이전 구현: SplayTreeSet + 외부 가변 상태(_treePct)에 의존하는 비교자 ──

_Run _runSplayTree(List<_Frame> frames) {
  final feed = MarketFeed();
  final codesAll = [for (final s in feed.symbols) s.code];
  feed.dispose();

  final treePct = <String, double>{};
  for (final c in codesAll) {
    treePct[c] = 0;
  }
  var comparisons = 0;
  int compareByPctDesc(String a, String b) {
    comparisons++;
    if (a == b) return 0;
    final pa = treePct[a] ?? 0;
    final pb = treePct[b] ?? 0;
    final c = pb.compareTo(pa);
    return c != 0 ? c : a.compareTo(b);
  }

  final ranked = SplayTreeSet<String>(compareByPctDesc)..addAll(codesAll);
  comparisons = 0;

  final samples = Float64List(frames.length);
  final tops = <List<String>>[];
  final sw = Stopwatch();

  for (var f = 0; f < frames.length; f++) {
    final fr = frames[f];
    sw
      ..reset()
      ..start();

    // 갱신: pct가 바뀐 종목을 빼고 → 값 갱신 → 다시 넣는다. O(dirty·log n).
    for (var j = 0; j < fr.codes.length; j++) {
      final c = fr.codes[j];
      ranked.remove(c); // 트리는 아직 옛 pct 기준이어야 제거가 성립한다
      treePct[c] = fr.pcts[j];
      ranked.add(c);
    }
    // 선택: 이미 정렬돼 있으니 앞에서 20개.
    final out = <String>[];
    for (final c in ranked) {
      out.add(c);
      if (out.length >= kTop) break;
    }

    sw.stop();
    samples[f] = sw.elapsedMicroseconds.toDouble();
    tops.add(out);
  }
  return _Run(samples, tops, comparisons);
}

// ── B) 현재 구현: Float64List O(1) 갱신 + 20슬롯 선형 선택 ─────────────────

_Run _runLinearScan(List<_Frame> frames) {
  final feed = MarketFeed();
  final symbols = feed.symbols;
  feed.dispose();

  final indexOf = <String, int>{};
  for (var i = 0; i < symbols.length; i++) {
    indexOf[symbols[i].code] = i;
  }
  final pct = Float64List(symbols.length);
  final n = symbols.length;

  final samples = Float64List(frames.length);
  final tops = <List<String>>[];
  final sw = Stopwatch();

  final topIdx = Int32List(kTop);
  final topPct = Float64List(kTop);

  for (var f = 0; f < frames.length; f++) {
    final fr = frames[f];
    sw
      ..reset()
      ..start();

    // 갱신: 배열 한 칸 덮어쓰기. O(dirty), log n 없음.
    for (var j = 0; j < fr.codes.length; j++) {
      pct[indexOf[fr.codes[j]]!] = fr.pcts[j];
    }

    // 선택: 전체 1회 스캔 + 20슬롯 삽입 (market_store._topK 와 동일한 로직).
    var filled = 0;
    var floor = double.negativeInfinity;
    for (var i = 0; i < n; i++) {
      final p = pct[i];
      if (filled == kTop && p <= floor) continue;
      var q = filled < kTop ? filled : kTop - 1;
      while (q > 0 && topPct[q - 1] < p) {
        topPct[q] = topPct[q - 1];
        topIdx[q] = topIdx[q - 1];
        q--;
      }
      topPct[q] = p;
      topIdx[q] = i;
      if (filled < kTop) filled++;
      if (filled == kTop) floor = topPct[kTop - 1];
    }
    final out = [for (var r = 0; r < filled; r++) symbols[topIdx[r]].code];

    sw.stop();
    samples[f] = sw.elapsedMicroseconds.toDouble();
    tops.add(out);
  }
  return _Run(samples, tops, 0);
}
