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
    // 화면 수명과 구독 수명을 일치시키는 지점.
    // 상세가 떠 있는 동안 목록은 어차피 보이지 않으므로(offstage) 갱신을 멈추고,
    // 이 종목의 체결가만 링버퍼에 쌓기 시작한다. → 상세 중 목록 rebuild 0회.
    widget.store.openDetail(widget.code); // 목록 pause + 스파크라인 시작
  }

  @override
  void dispose() {
    // pop 시 반드시 짝을 맞춰 해제. 안 하면 목록이 멈춘 채로 돌아가고
    // 스파크라인 버퍼도 계속 쌓인다(누수).
    widget.store.closeDetail(); // 목록 재개 + 새로고침
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // 종목명은 tick으로 변하지 않으므로 리스너 밖(=AppBar)에서 한 번만 읽는다.
        title: Text(widget.store.detailOf(widget.code).name),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      // 포커스 종목 신호가 바뀔 때만 rebuild(coalesced). 데이터는 그때 detailOf로 읽음.
      // 목록과 동일한 패턴: notifier는 "바뀌었다"는 신호(int)만 나르고,
      // 실제 값은 빌드 시점에 store에서 당겨오므로 항상 최신 상태가 그려진다.
      body: ValueListenableBuilder<int>(
        valueListenable: widget.store.notifierFor(widget.code),
        builder: (_, _, _) {
          // rebuild 범위를 body로 한정 → Scaffold/AppBar는 다시 만들지 않는다.
          final d = widget.store.detailOf(widget.code);
          return _DetailBody(d: d);
        },
      ),
    );
  }
}

/// 상세 본문. 매 프레임 새로 만들어지므로 상태를 갖지 않고,
/// 전달받은 [DetailView] 스냅샷만으로 그린다(그리는 쪽과 store 상태를 분리).
class _DetailBody extends StatelessWidget {
  const _DetailBody({required this.d});
  final DetailView d;

  @override
  Widget build(BuildContext context) {
    // 색 기준: 거래정지(회색) > 상승(빨강) > 하락(파랑) > 보합(회색).
    // 정지 판정을 먼저 두어 "정지인데 빨간색" 같은 모순을 막는다.
    final up = d.changePct > 0;
    final down = d.changePct < 0;
    final color = d.halted
        ? Colors.grey
        : up
            ? Colors.red
            : down
                ? Colors.blue
                : Colors.grey;
    // 상승(+)만 '+' 부호, 하락은 _fmt의 '-', 보합은 무부호(색·부호 기준을 일치).
    final sign = up ? '+' : '';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Text(d.code, style: TextStyle(color: Colors.grey.shade600)),
            // 거래정지일 때만 배지 삽입(...스프레드 → 평상시엔 위젯 자체가 없음).
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

        // 스파크라인: 상세 진입 이후 쌓인 최근 체결가(최대 60개 링버퍼)를 선으로.
        // 점이 1개뿐이면 선을 그릴 수 없으므로 수집 중 문구로 대체한다.
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

        // 시/고/저 + 거래량. tick마다 UI에서 계산하지 않고 store가 스트림에서
        // 누적해 둔 값을 그대로 읽는다(= 화면은 표시만 담당).
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
    // 절댓값에만 천 단위 콤마를 넣고 부호는 따로 붙인다.
    // (음수의 '-'를 자릿수 계산에 포함시키면 "-,123" 처럼 콤마가 잘못 붙는다.)
    final neg = v < 0;
    final s = v.abs().toStringAsFixed(0);
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return neg ? '-$buf' : buf.toString();
  }
}

/// 최근 체결가 스파크라인. 매 tick이 아니라 상세 rebuild(coalesced) 시에만 그린다.
class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.prices, this.color);

  final List<double> prices;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // 창(window) 안의 min/max로 매번 y축을 다시 정규화한다.
    // 절대 가격이 아니라 "이 구간의 상대 움직임"을 보여주는 것이 목적.
    double min = prices.first, max = prices.first;
    for (final p in prices) {
      if (p < min) min = p;
      if (p > max) max = p;
    }
    // 모든 값이 같으면(평탄) range=0 → 0으로 나눠 NaN이 되므로 1.0으로 대체.
    final range = (max - min).abs() < 1e-9 ? 1.0 : (max - min);
    // 점 n개를 폭에 균등 배치. paint는 length>=2일 때만 호출되므로 0 나눗셈 없음.
    final dx = size.width / (prices.length - 1);

    final path = Path();
    for (var i = 0; i < prices.length; i++) {
      final x = dx * i;
      // 캔버스 y는 아래로 증가 → height에서 빼서 위아래를 뒤집는다(고가가 위).
      final y = size.height - ((prices[i] - min) / range) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    // 채우기 없이 선만(stroke) — Path를 한 번에 그려 draw 콜을 1회로 유지.
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) {
    // 상세는 프레임당 1회(coalesced) 재빌드되며 종목은 하나뿐이라 매번 다시 그려도
    // 저렴하다. length/last만 비교하던 이전 방식은 링버퍼가 꽉 찬 뒤 평탄한 tick으로
    // 창이 왼쪽으로 밀릴 때(길이·마지막값 동일) 변화를 놓쳐 stale 프레임을 남겼다.
    if (old.color != color || old.prices.length != prices.length) return true;
    for (var i = 0; i < prices.length; i++) {
      if (old.prices[i] != prices[i]) return true;
    }
    return false;
  }
}
