import 'package:flutter/material.dart';

import '../domain/symbol_view.dart';
import '../state/market_store.dart';

/// 종목 상세 화면.
///
/// - 동일 feed에서 실시간 갱신(포커스 종목의 신호만 구독).
/// - 진입 시 `store.openDetail`로 목록 갱신을 pause(구독 수명 관리),
///   종료 시 `store.closeDetail`로 재개 + 목록 강제 새로고침.
/// - 시/고/저는 store가 tick 흐름에서 누적한 값, 스파크라인은 최근 N개 링버퍼.
class DetailScreen extends StatefulWidget {
  const DetailScreen({super.key, required this.store, required this.code});

  final MarketStore store;
  final String code;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  @override
  void initState() {
    super.initState();
    widget.store.openDetail(widget.code); // 목록 pause + 스파크라인 시작
  }

  @override
  void dispose() {
    widget.store.closeDetail(); // 목록 재개 + 새로고침
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.store.detailOf(widget.code).name),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      // 포커스 종목 신호가 바뀔 때만 rebuild(coalesced). 데이터는 그때 detailOf로 읽음.
      body: ValueListenableBuilder<int>(
        valueListenable: widget.store.notifierFor(widget.code),
        builder: (_, _, _) {
          final d = widget.store.detailOf(widget.code);
          return _DetailBody(d: d);
        },
      ),
    );
  }
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({required this.d});
  final DetailView d;

  @override
  Widget build(BuildContext context) {
    final up = d.changePct > 0;
    final down = d.changePct < 0;
    final color = d.halted
        ? Colors.grey
        : up
            ? Colors.red
            : down
                ? Colors.blue
                : Colors.grey;
    final sign = d.changeAbs >= 0 ? '+' : '';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Text(d.code, style: TextStyle(color: Colors.grey.shade600)),
            if (d.halted) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text('거래정지', style: TextStyle(fontSize: 12)),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '${_fmt(d.price)}원',
          style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
        ),
        Text(
          '$sign${_fmt(d.changeAbs)}  ($sign${d.changePct.toStringAsFixed(2)}%)',
          style: TextStyle(color: color, fontSize: 16),
        ),
        const SizedBox(height: 20),

        // 스파크라인
        Container(
          height: 120,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.all(8),
          child: d.spark.length < 2
              ? const Center(child: Text('데이터 수집 중…'))
              : CustomPaint(
                  painter: _SparklinePainter(d.spark, color),
                  size: Size.infinite,
                ),
        ),
        const SizedBox(height: 20),

        // 시/고/저 + 거래량
        _row('시가', '${_fmt(d.open)}원'),
        _row('고가', '${_fmt(d.high)}원'),
        _row('저가', '${_fmt(d.low)}원'),
        _row('전일종가', '${_fmt(d.previousClose)}원'),
        _row('당일 거래량', _fmt(d.dayVolume.toDouble())),
      ],
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: TextStyle(color: Colors.grey.shade700)),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      );

  static String _fmt(double v) {
    final s = v.toStringAsFixed(0);
    // 천 단위 콤마
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}

/// 최근 체결가 스파크라인. 매 tick이 아니라 상세 rebuild(coalesced) 시에만 그린다.
class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.prices, this.color);

  final List<double> prices;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    double min = prices.first, max = prices.first;
    for (final p in prices) {
      if (p < min) min = p;
      if (p > max) max = p;
    }
    final range = (max - min).abs() < 1e-9 ? 1.0 : (max - min);
    final dx = size.width / (prices.length - 1);

    final path = Path();
    for (var i = 0; i < prices.length; i++) {
      final x = dx * i;
      final y = size.height - ((prices[i] - min) / range) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.prices.length != prices.length ||
      (prices.isNotEmpty && old.prices.last != prices.last) ||
      old.color != color;
}
