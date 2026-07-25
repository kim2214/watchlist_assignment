import 'dart:async';

import 'package:flutter/material.dart';

import '../seed/market_feed.dart';
import '../seed/market_models.dart';

/// ============================================================================
/// BASELINE (before) — 일부러 순진하게 짠 버전. before/after 비교의 기준선.
///
/// 의도적으로 아래를 그대로 둔다 (이게 baseline의 정의):
///   - tick 배치마다 setState()로 화면 전체를 rebuild
///   - 요약값(시총 합계)을 매 build마다 전체 2,000 순회로 재계산
///   - 행에 RepaintBoundary 없음
///   - 역순 tick / 거래정지 / 스트림 에러 처리 없음
///
/// 실행: `flutter run --profile -t lib/main_baseline.dart -d [device]`
/// ============================================================================
class NaiveWatchlistScreen extends StatefulWidget {
  const NaiveWatchlistScreen({super.key, this.feed, this.autoStart = true});

  /// 벤치마크에서 pump()로 구동하기 위해 외부 feed를 주입할 수 있다.
  /// null이면 화면이 직접 생성/소유한다(=앱 실행 경로).
  final MarketFeed? feed;

  /// false면 feed.start()를 호출하지 않는다(=pump 기반 벤치마크 경로).
  final bool autoStart;

  @override
  State<NaiveWatchlistScreen> createState() => _NaiveWatchlistScreenState();
}

class _NaiveWatchlistScreenState extends State<NaiveWatchlistScreen> {
  late final MarketFeed _feed = widget.feed ?? MarketFeed();
  bool get _ownsFeed => widget.feed == null;
  StreamSubscription<List<QuoteTick>>? _sub;

  late final List<SymbolInfo> _symbols;
  final Map<String, double> _previousClose = {};
  final Map<String, int> _listedShares = {};
  final Map<String, double> _price = {};
  final Map<String, int> _volume = {};

  int _batchCount = 0;

  @override
  void initState() {
    super.initState();
    _symbols = _feed.symbols;

    for (final e in _feed.initialSnapshot()) {
      _previousClose[e.info.code] = e.previousClose;
      _listedShares[e.info.code] = e.info.listedShares;
      _price[e.info.code] = e.price;
      _volume[e.info.code] = e.dayVolume;
    }

    // 순진하게: 배치가 올 때마다 상태를 덮어쓰고 화면 전체를 setState.
    _sub = _feed.ticks.listen((batch) {
      for (final tick in batch) {
        _price[tick.code] = tick.price; // timestampMs 무시 (역순 그대로 반영)
        _volume[tick.code] = tick.dayVolume;
      }
      setState(() {
        _batchCount++;
      });
    });

    if (widget.autoStart) _feed.start();
  }

  @override
  void dispose() {
    _sub?.cancel();
    if (_ownsFeed) _feed.dispose(); // 주입된 feed는 소유자(벤치마크)가 정리
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 매 build마다 전체 2,000 순회로 시총 합계 재계산 (일부러 비효율).
    double totalMarketCap = 0;
    for (final s in _symbols) {
      totalMarketCap += (_price[s.code] ?? 0) * (_listedShares[s.code] ?? 0);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('관심종목 (baseline)'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Colors.grey.shade100,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('표시 중: ${_symbols.length} 종목   |   배치 수신: $_batchCount'),
                const SizedBox(height: 4),
                Text('시가총액 합계: ${_formatCap(totalMarketCap)}'),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: _symbols.length,
              itemBuilder: (context, index) {
                final s = _symbols[index];
                final price = _price[s.code] ?? 0;
                final prevClose = _previousClose[s.code] ?? price;
                final changePct =
                    prevClose == 0 ? 0.0 : (price - prevClose) / prevClose * 100;
                final volume = _volume[s.code] ?? 0;

                final color = changePct > 0
                    ? Colors.red
                    : changePct < 0
                        ? Colors.blue
                        : Colors.grey;

                return ListTile(
                  dense: true,
                  title: Text(s.name),
                  subtitle: Text('${s.code}  ·  거래량 $volume'),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        _formatPrice(price),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '${changePct >= 0 ? '+' : ''}${changePct.toStringAsFixed(2)}%',
                        style: TextStyle(color: color, fontSize: 12),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _formatPrice(double v) => '${v.toStringAsFixed(0)}원';

  String _formatCap(double v) {
    if (v >= 1e12) return '${(v / 1e12).toStringAsFixed(1)}조';
    if (v >= 1e8) return '${(v / 1e8).toStringAsFixed(1)}억';
    return v.toStringAsFixed(0);
  }
}
