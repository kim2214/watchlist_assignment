import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/symbol_view.dart';
import '../seed/market_feed.dart';
import '../state/market_store.dart';
import 'detail_screen.dart';

/// 개선본(after) 목록 화면.
///
/// 갱신 경로:
///  - 요약 / Top-20 / 에러배너 = 각각 별도 ValueNotifier 구독 (행과 격리)
///  - 각 행 = 자기 종목 notifier만 구독 + RepaintBoundary
///  - ListView.builder가 "보이는 행"만 만들고, notifier가 "바뀐 종목"만 알리므로
///    결과적으로 (보이는 ∩ 바뀐) 행만 rebuild된다.
class WatchlistScreen extends StatefulWidget {
  const WatchlistScreen({super.key, this.feed, this.autoStart = true});

  /// 벤치마크에서 pump()로 구동하기 위해 외부 feed를 주입할 수 있다.
  /// null이면 화면이 직접 생성/소유한다(=앱 실행 경로).
  final MarketFeed? feed;

  /// false면 feed.start()를 호출하지 않는다(=pump 기반 벤치마크 경로).
  final bool autoStart;

  @override
  State<WatchlistScreen> createState() => _WatchlistScreenState();
}

class _WatchlistScreenState extends State<WatchlistScreen> {
  late final MarketStore _store;
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _store = MarketStore(widget.feed ?? MarketFeed(), ownsFeed: widget.feed == null)
      ..start(autoStart: widget.autoStart);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _store.dispose();
    super.dispose();
  }

  // keystroke마다 필터를 돌리지 않고, 입력이 멎으면 200ms 후 1회만 적용.
  void _onQueryChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () => _store.setQuery(q));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('관심종목'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          _SearchField(controller: _searchCtrl, onChanged: _onQueryChanged),
          _ErrorBanner(store: _store),
          _SummaryBar(store: _store),
          _TopMoversStrip(store: _store),
          const Divider(height: 1),
          // 필터 "구조"(목록 길이/구성)가 바뀔 때만 리스트를 다시 빌드.
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: _store.filterVersion,
              builder: (_, _, _) {
                final count = _store.visibleCount;
                if (count == 0) {
                  return const Center(child: Text('검색 결과가 없습니다'));
                }
                return ListView.builder(
                  itemCount: count,
                  itemExtent: 60, // 고정 높이 → 레이아웃 계산 절감
                  itemBuilder: (context, index) {
                    final code = _store.codeAt(index);
                    return RepaintBoundary(
                      // int 신호가 바뀔 때만 rebuild. 데이터는 그 시점에 viewOf()로
                      // 라이브 상태에서 읽으므로 스크롤로 새로 보이는 행도 항상 최신.
                      child: ValueListenableBuilder<int>(
                        valueListenable: _store.notifierFor(code),
                        builder: (_, _, _) => _WatchRow(
                          name: _store.nameAt(index),
                          code: code,
                          view: _store.viewOf(code),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  DetailScreen(store: _store, code: code),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 검색 입력. 초성(ㄱㅇ)·완성형(전자)·종목코드(000590) 모두 지원.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        decoration: InputDecoration(
          isDense: true,
          hintText: '초성(ㄱㅇ) · 이름(전자) · 코드(000590)',
          prefixIcon: const Icon(Icons.search, size: 20),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }
}

/// 스트림 에러 배너. 에러 중에만 표시되고 다음 배치에서 자동 사라진다.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.store});
  final MarketStore store;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: store.error,
      builder: (_, msg, _) {
        if (msg == null) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          color: Colors.orange.shade100,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              const Icon(Icons.sync_problem, size: 16, color: Colors.orange),
              const SizedBox(width: 8),
              Expanded(child: Text('일시적 피드 지연 — 복구 중  ($msg)')),
            ],
          ),
        );
      },
    );
  }
}

/// 요약 영역 (표시 종목 수 + 시총 합계). summary notifier만 구독.
class _SummaryBar extends StatelessWidget {
  const _SummaryBar({required this.store});
  final MarketStore store;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MarketSummary>(
      valueListenable: store.summary,
      builder: (_, s, _) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        color: Colors.grey.shade100,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('표시 중: ${s.count} 종목'),
            const SizedBox(height: 4),
            Text('시가총액 합계: ${_formatCap(s.totalMarketCap)}'),
          ],
        ),
      ),
    );
  }
}

/// 등락률 상위 20 (가로 스크롤). topMovers notifier만 구독.
class _TopMoversStrip extends StatelessWidget {
  const _TopMoversStrip({required this.store});
  final MarketStore store;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: ValueListenableBuilder<List<TopMover>>(
        valueListenable: store.topMovers,
        builder: (_, movers, _) => ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          itemCount: movers.length,
          itemBuilder: (_, i) {
            final m = movers[i];
            // 등락률 내림차순 상위지만, 하락장/필터 집합에선 음수도 올 수 있다.
            // 부호·색을 changePct 기준으로 정확히 표시.
            final up = m.changePct > 0;
            final down = m.changePct < 0;
            final color = m.halted
                ? Colors.grey
                : up
                    ? Colors.red
                    : down
                        ? Colors.blue
                        : Colors.grey;
            return Container(
              width: 96,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('${i + 1}. ${m.name}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    '${m.changePct >= 0 ? '+' : ''}${m.changePct.toStringAsFixed(2)}%',
                    style: TextStyle(color: color, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 한 행. 자기 종목 notifier의 SymbolView만 받아 그린다.
class _WatchRow extends StatelessWidget {
  const _WatchRow({
    required this.name,
    required this.code,
    required this.view,
    required this.onTap,
  });

  final String name;
  final String code;
  final SymbolView view;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = view.halted
        ? Colors.grey
        : view.changePct > 0
            ? Colors.red
            : view.changePct < 0
                ? Colors.blue
                : Colors.grey;

    return ListTile(
      dense: true,
      onTap: onTap,
      title: Row(
        children: [
          Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
          if (view.halted) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(3),
              ),
              child: const Text('정지', style: TextStyle(fontSize: 10)),
            ),
          ],
        ],
      ),
      subtitle: Text('$code  ·  거래량 ${view.dayVolume}'),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('${view.price.toStringAsFixed(0)}원',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          Text(
            '${view.changePct >= 0 ? '+' : ''}${view.changePct.toStringAsFixed(2)}%',
            style: TextStyle(color: color, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

String _formatCap(double v) {
  if (v >= 1e12) return '${(v / 1e12).toStringAsFixed(1)}조';
  if (v >= 1e8) return '${(v / 1e8).toStringAsFixed(1)}억';
  return v.toStringAsFixed(0);
}
